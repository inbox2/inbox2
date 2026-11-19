// Where the admin console is mounted. On its own host (console.inbox2.com) it sits at the
// root: /, /domains, /people. Everywhere else (mail.inbox2.com, dev, the desktop app) under
// /console/. A Pages build with VITE_CONSOLE_ORIGIN sends /console/... from the other hosts
// there (routes.jsx ConsoleMount); dev and desktop have none and keep /console. The session
// cookie is the API's, so one sign-in covers every host.
const host = typeof window === 'undefined' ? '' : window.location.hostname
export const CONSOLE_HOST = host.startsWith('console.')
export const CONSOLE_ORIGIN = (import.meta.env.VITE_CONSOLE_ORIGIN || '').replace(/\/+$/, '')
// The console's first path segments (its child routes). Org slugs cannot shadow them: static routes win.
export const CONSOLE_SEGMENTS = ['domains', 'people', 'team', 'rules', 'disk', 'billing', 'api-keys', 'apps', 'applications']

/** A console page's path on this host: consolePath('domains') is /domains here, /console/domains elsewhere. */
export const consolePath = (where = '') => (CONSOLE_HOST ? `/${where}` : `/console${where ? `/${where}` : ''}`)

/** Whether a pathname is a console page on this host. */
export function isConsolePath(pathname) {
  if (/^\/console(\/|$)/.test(pathname)) return true
  if (!CONSOLE_HOST) return false
  // /disk is the console's Disk admin page; /disk/<anything> is Disk itself (an old link), not ours.
  if (/^\/disk\/./.test(pathname)) return false
  return pathname === '/' || CONSOLE_SEGMENTS.includes(pathname.split('/')[1])
}

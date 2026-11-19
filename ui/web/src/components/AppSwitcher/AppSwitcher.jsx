import { useCallback, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { useNavigate } from 'react-router'
import Avatar from '../Avatar'
import Icon from '../Icon'
import useAuth from '../../hooks/useAuth'
import useDismiss from '../../hooks/useDismiss'
import { isTauri } from '../../lib/tauri'
import { openLink } from '../../lib/openLink'
import { isAdminRole } from '../../lib/orgRoles'
import { CONSOLE_WEB_URL, DISK_WEB_URL } from '../../lib/webOrigin'
import { CONSOLE_ORIGIN, consolePath } from '../../lib/consoleHost'
import { DISK_ORIGIN, MAIL_ORIGIN, diskPath } from '../../lib/disk/model'
import styles from './AppSwitcher.module.css'

/**
 * The avatar at the top right: who is signed in, and the apps as tiles (Google's app
 * launcher), so a new app is one more tile. Mail chrome uses the dark look; the console and
 * Disk the cream one (variant="light").
 *
 * Getting there: each app may live on its own host (mail./disk./console.inbox2.com). On
 * another host that is a full page load, on this one a route. The desktop app keeps mail
 * and settings and opens Disk and the console in the browser.
 */
export default function AppSwitcher({ current, variant = 'chrome', settingsPath }) {
  const navigate = useNavigate()
  const { user, organizations } = useAuth()
  const [open, setOpen] = useState(false)
  const ref = useRef(null)
  const triggerRef = useRef(null)
  const panelRef = useRef(null)
  // The panel is portaled to <body> (the mail chrome clips what overflows it), so "inside"
  // is the avatar or the panel. Escape hands focus back to the avatar.
  const inside = useMemo(() => ({ get current() { return { contains: (t) => !!(ref.current?.contains(t) || panelRef.current?.contains(t)) } } }), [])
  useDismiss(inside, useCallback((e) => { setOpen(false); if (e.type === 'keydown') triggerRef.current?.focus() }, []), open)
  // Pinned under the avatar, right edges aligned, and kept there on scroll/resize; focus the first item.
  useLayoutEffect(() => {
    const panel = panelRef.current
    if (!open || !panel) return undefined
    const place = () => {
      const r = triggerRef.current.getBoundingClientRect()
      panel.style.setProperty('--switcher-top', `${r.bottom + 8}px`)
      panel.style.setProperty('--switcher-right', `${Math.max(8, window.innerWidth - r.right)}px`)
    }
    place()
    panel.querySelector('button')?.focus()
    window.addEventListener('resize', place)
    window.addEventListener('scroll', place, true)
    return () => {
      window.removeEventListener('resize', place)
      window.removeEventListener('scroll', place, true)
    }
  }, [open])
  // Mail settings live under the org (ChromeBar passes its primary slug); elsewhere the first org's.
  const slug = organizations?.[0]?.slug
  const settings = settingsPath || (slug ? `/${slug}/settings` : '/settings')

  // origin + hostPath when the app lives on another host, else the route here.
  const go = ({ origin, hostPath = '/', path, webUrl }) => {
    setOpen(false)
    if (isTauri() && webUrl) openLink(webUrl)
    else if (origin && origin !== window.location.origin) window.location.assign(`${origin}${hostPath}`)
    else navigate(path)
  }
  const name = user?.display_name || user?.username
  const isAdmin = organizations?.some((o) => isAdminRole(o.role))
  const toConsole = { origin: CONSOLE_ORIGIN, path: consolePath(), webUrl: CONSOLE_WEB_URL }
  const apps = [
    { key: 'mail', label: 'Mail', img: '/console/open-mail.png', to: { origin: MAIL_ORIGIN, path: '/' } },
    { key: 'disk', label: 'Disk', img: '/console/open-disk.png', to: { origin: DISK_ORIGIN, path: diskPath(), webUrl: DISK_WEB_URL } },
    ...(isAdmin ? [{ key: 'console', label: 'Console', img: '/console/open-console.png', to: toConsole }] : []),
  ]
  const toSettings = { origin: MAIL_ORIGIN, hostPath: settings, path: settings }

  return (
    <div ref={ref} className={styles.wrap} data-variant={variant}>
      <button ref={triggerRef} type="button" className={styles.trigger} onClick={() => setOpen((o) => !o)} aria-haspopup="menu" aria-expanded={open} title={name ? `${name}: apps and settings` : 'Apps and settings'}>
        <Avatar name={name} email={user?.email} src={user?.avatar_url} size={24} />
      </button>
      {open && createPortal(
        <div ref={panelRef} className={`${styles.panel} ${variant === 'light' ? 'management' : ''}`} data-variant={variant} role="menu">
          <div className={styles.who}>
            <Avatar name={name} email={user?.email} src={user?.avatar_url} size={36} />
            <span className={styles.whoText}>
              <b>{name}</b>
              <span>{user?.email}</span>
            </span>
          </div>
          {/* Settings: one wide row above the apps, as Google puts "Manage your account". */}
          <button type="button" role="menuitem" className={styles.settings} onClick={() => go(toSettings)}>
            <span className={styles.settingsIcon}><Icon name="gear" size={16} /></span>
            Settings
          </button>
          <div className={styles.tiles}>
            {apps.map((a) => (
              <button key={a.key} type="button" role="menuitem" className={styles.tile} aria-current={a.key === current ? 'page' : undefined} onClick={() => go(a.to)}>
                <img className={styles.tileImg} src={a.img} alt="" />
                {a.label}
              </button>
            ))}
          </div>
          {/* Admins: the org's real settings live in the web console (the desktop opens it in the browser). */}
          {isAdmin && (
            <button type="button" role="menuitem" className={styles.admin} onClick={() => go(toConsole)}>
              <Icon name="checkmark.shield.fill" size={14} />
              Admin settings
            </button>
          )}
        </div>,
        document.body,
      )}
    </div>
  )
}

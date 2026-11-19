import { useRef, useEffect } from 'react'
import Avatar from '../Avatar'
import styles from './ChannelAvatar.module.css'

/**
 * An Avatar with a brand-ringed channel glyph badge (Instagram / Messenger /
 * WhatsApp …). The single source for the social-channel avatar shared by the
 * conversation list rows and the right-click preview card — keep the badge ring
 * + sizing here rather than re-deriving it per consumer.
 *
 * Props:
 *   name, src, unread — forwarded to Avatar
 *   brand             — a CHANNEL_BRAND entry ({ accent, logo, label })
 *   size              — avatar diameter (default 37)
 *   badgeSize         — channel badge diameter (default 20); icon = badgeSize − 4
 */
export default function ChannelAvatar({ name, src, brand, size = 37, badgeSize = 20, unread = false }) {
  const ref = useRef(null)
  useEffect(() => {
    const el = ref.current
    if (!el) return
    // Set via custom properties so no inline styles are emitted (ESLint bans style={{}}).
    el.style.setProperty('--brand-accent', brand.accent)
    el.style.setProperty('--badge-size', `${badgeSize}px`)
    el.style.setProperty('--badge-icon', `${badgeSize - 4}px`)
  }, [brand.accent, badgeSize])

  return (
    <div ref={ref} className={styles.wrap}>
      <Avatar name={name} src={src} size={size} unread={unread} />
      <span className={styles.badge}>
        <img src={brand.logo} alt={brand.label} className={styles.icon} />
      </span>
    </div>
  )
}

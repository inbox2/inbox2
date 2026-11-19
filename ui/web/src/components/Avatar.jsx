import { useRef, useEffect, useState } from 'react'
import styles from './Avatar.module.css'
import { useAvatarUrl } from '../lib/avatar'

const COLORS = [
  { bg: '#5E4AE3', fg: '#E8E0FF' },
  { bg: '#E0544E', fg: '#FFE0DE' },
  { bg: '#2D9CDB', fg: '#D6EFFF' },
  { bg: '#27AE60', fg: '#D4F5E2' },
  { bg: '#E67E22', fg: '#FDE8D0' },
  { bg: '#E84393', fg: '#FDDDEF' },
  { bg: '#00B894', fg: '#CCF5EA' },
  { bg: '#6C5CE7', fg: '#E4E0FA' },
]

function hashCode(str) {
  let hash = 0
  for (let i = 0; i < str.length; i++) {
    hash = str.charCodeAt(i) + ((hash << 5) - hash)
  }
  return Math.abs(hash)
}

function getInitials(name) {
  return name.split(' ').map(w => w[0]).join('').toUpperCase().slice(0, 2)
}

function getColor(name) {
  return COLORS[hashCode(name) % COLORS.length]
}

export default function Avatar({ name, email, size = 28, unread = false, src, loading = false }) {
  const ref = useRef(null)
  const color = getColor(name || '')
  const initials = getInitials(name || '?')

  // Public picture for the address (lib/avatar.js), behind any exact `src`.
  const publicSrc = useAvatarUrl(email)

  useEffect(() => {
    if (ref.current) {
      ref.current.style.setProperty('--avatar-size', `${size}px`)
      ref.current.style.setProperty('--avatar-bg', color.bg)
      ref.current.style.setProperty('--avatar-fg', color.fg)
      ref.current.style.setProperty('--avatar-font', `${Math.round(size * 0.38)}px`)
    }
  }, [size, color.bg, color.fg])

  // Candidate chain, highest-confidence first: an exact match (e.g. Apollo's
  // photo_url) wins; otherwise the public picture; otherwise initials.
  const candidates = [src, publicSrc].filter(Boolean)
  const [failed, setFailed] = useState(() => new Set())
  // Reset the failed set during render (not in an effect) when the identity
  // changes, so a new contact re-attempts its candidates.
  const identity = `${src || ''}|${email || ''}`
  const [prevIdentity, setPrevIdentity] = useState(identity)
  if (prevIdentity !== identity) {
    setPrevIdentity(identity)
    setFailed(new Set())
  }
  const activeSrc = candidates.find(c => !failed.has(c)) || null

  const cls = [styles.avatar]
  if (unread) cls.push(styles.unread)
  if (loading) cls.push(styles.loading)

  return (
    <div ref={ref} className={cls.join(' ')}>
      <div className={styles.avatarInner}>
        <div className={styles.avatarContent}>
          {activeSrc && (
            <img
              key={activeSrc}
              src={activeSrc}
              alt={name}
              className={styles.avatarImg}
              onError={() => setFailed(prev => new Set(prev).add(activeSrc))}
            />
          )}
          <span className={styles.avatarFallback}>
            {initials}
          </span>
          {loading && <div className={styles.loadingOverlay}><div className={styles.spinner} /></div>}
        </div>
      </div>
    </div>
  )
}

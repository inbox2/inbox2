// Disk's 16px line action glyphs from the mockup's `ic` set; part of Disk's own icon set (F3 exception, see FileTypeIcon).
import { ACTION_PATHS } from './glyphs'
import styles from './FileTypeIcon.module.css'

/** One of the Disk action glyphs, drawn in currentColor. */
export default function ActionIcon({ name, size = 16 }) {
  return (
    <svg className={styles.icon} width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor"
      strokeWidth={name === 'more' ? 2.4 : 1.6} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={ACTION_PATHS[name]} />
    </svg>
  )
}

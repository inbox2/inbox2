import { ACTION_PATHS } from '../FileTypeIcon/glyphs'
import styles from './StarToggle.module.css'

/* A star beside a title: outlined when off, filled when on. A real toggle button
 * (aria-pressed) so it is reachable and announced, drawn as just the star. */
export default function StarToggle({ on, onToggle, label, size = 22 }) {
  return (
    <button type="button" className={styles.star} aria-pressed={!!on} aria-label={on ? `Remove ${label} from Starred` : `Star ${label}`}
      title={on ? 'Starred' : 'Star'} onClick={() => onToggle(!on)}>
      <svg width={size} height={size} viewBox="0 0 16 16" fill={on ? 'currentColor' : 'none'} stroke="currentColor" strokeWidth={1.4}
        strokeLinejoin="round" aria-hidden="true">
        <path d={ACTION_PATHS.star} />
      </svg>
    </button>
  )
}

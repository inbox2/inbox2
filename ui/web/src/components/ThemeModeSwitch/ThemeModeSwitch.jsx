import Icon from '../Icon'
import { THEME_MODE } from '../../lib/themes'
import styles from './ThemeModeSwitch.module.css'

const OPTIONS = [
  { mode: THEME_MODE.DARK, label: 'Dark', icon: 'moon.fill' },
  { mode: THEME_MODE.LIGHT, label: 'Light', icon: 'sun.max.fill' },
]

/**
 * Dark or light: one pill with a thumb that slides between the two. Shared by
 * the setup wizard and Settings › Theme.
 *
 * Props: mode (THEME_MODE), onChange(mode).
 */
export default function ThemeModeSwitch({ mode, onChange }) {
  return (
    <div className={styles.pill} role="radiogroup" aria-label="Mode" data-mode={mode}>
      <span className={styles.thumb} aria-hidden="true" />
      {OPTIONS.map((o) => (
        <button
          key={o.mode}
          type="button"
          role="radio"
          aria-checked={mode === o.mode}
          className={`${styles.option} ${mode === o.mode ? styles.on : ''}`}
          onClick={() => onChange(o.mode)}
        >
          <Icon name={o.icon} size={14} />
          {o.label}
        </button>
      ))}
    </div>
  )
}

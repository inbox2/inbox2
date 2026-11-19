import Icon from '../Icon'
import styles from './DevModeIndicator.module.css'

/**
 * "Dev mode" badge, matching the indicator shown in settings. Render it
 * conditionally on `useDevMode()` (toggled anywhere with the backtick key).
 *
 * Props:
 *   className — extra class on the wrapper (for positioning)
 */
export default function DevModeIndicator({ className }) {
  const classes = [styles.indicator, className].filter(Boolean).join(' ')
  return (
    <div className={classes}>
      <Icon name="terminal" size={10} />
      <span>Dev mode</span>
    </div>
  )
}

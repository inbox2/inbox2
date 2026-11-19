import Icon from '../../../components/Icon'
import styles from '../setup.module.css'

// Where you are in setup. The MX path ends at sign-in (/login takes over).
const STANDALONE = [
  ['Welcome', ['welcome']],
  ['Look', ['look']],
  ['Channels', ['account-select', 'account-configure', 'meta-configure', 'oauth-waiting', 'oauth-exchanging']],
  ['AI', ['ai']],
  ['Extras', ['enrich']],
  ['Ready', ['complete']],
]
const MX = [['Welcome', ['welcome']], ['Look', ['look']], ['Sign in', ['signin']]]

/** Numbered dots on a rail: done = check, current = ringed, ahead = muted. */
export default function StepTrail({ step, mode }) {
  const steps = mode === 'mx' ? MX : STANDALONE
  const at = steps.findIndex(([, ids]) => ids.includes(step))
  return (
    <ol className={styles.stepper} aria-label="Setup progress">
      {steps.map(([label], i) => {
        const state = i < at ? 'done' : i === at ? 'current' : 'todo'
        return (
          <li key={label} className={styles.stepItem} data-state={state} aria-current={state === 'current' ? 'step' : undefined}>
            <span className={styles.stepDot}>
              {state === 'done' ? <Icon name="checkmark" size={11} /> : i + 1}
            </span>
            <span className={styles.stepLabel}>{label}</span>
          </li>
        )
      })}
    </ol>
  )
}

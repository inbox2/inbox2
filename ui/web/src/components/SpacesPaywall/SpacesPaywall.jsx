import Icon from '../Icon';
import styles from './SpacesPaywall.module.css';

/* Paywall overlay for the Spaces / AI-triage dashboard on free-plan orgs.
 * Rendered over a blurred mock-data preview of the treemap so the value is
 * visible-but-locked. Admins/owners get an "Upgrade now" CTA; members get a
 * "not on your plan — ask an admin" message (they can't change billing). */

const ADMIN_BULLETS = [
  { icon: 'sparkles', text: 'Jev sorts every email into the right team space, and flags what’s urgent' },
  { icon: 'square.grid.2x2', text: 'See Support, Sales, Finance and your own spaces at a glance' },
  { icon: 'bolt.fill', text: 'Jev triages each email as it lands. You write no rules.' },
];

export default function SpacesPaywall({ isAdmin = false, onUpgrade }) {
  return (
    <div className={styles.overlay}>
      <div className={styles.card}>
        <span className={styles.badge}>
          <Icon name="lock" size={12} /> Pro feature
        </span>

        {isAdmin ? (
          <>
            <h3 className={styles.title}>Get AI triage</h3>
            <p className={styles.body}>
              Jev sorts your team’s mail into spaces and labels what each
              thread needs. Every paid plan includes it.
            </p>
            <ul className={styles.bullets}>
              {ADMIN_BULLETS.map((b) => (
                <li key={b.text} className={styles.bullet}>
                  <Icon name={b.icon} size={14} className={styles.bulletIcon} />
                  <span>{b.text}</span>
                </li>
              ))}
            </ul>
            <button type="button" className={styles.cta} onClick={onUpgrade}>
              View pricing
            </button>
            <p className={styles.poweredBy}>
              <Icon name="sparkles" size={12} className={styles.poweredMark} />
              Triage by Jev, from TypeSafe
            </p>
          </>
        ) : (
          <>
            <h3 className={styles.title}>AI triage isn’t on your plan</h3>
            <p className={styles.body}>
              Jev from TypeSafe sorts your team’s mail into spaces.
              Your plan doesn’t include it.
            </p>
            <p className={styles.askAdmin}>
              <Icon name="person.crop.circle.badge.exclamationmark" size={15} className={styles.bulletIcon} />
              Ask an owner or admin to upgrade your workspace.
            </p>
          </>
        )}
      </div>
    </div>
  );
}

import MgmtCard from './MgmtCard';
import styles from './MgmtAuthCard.module.css';

/* The centred auth/wizard card used across login, signup, password reset and the
 * onboarding steps — a white management card with a Clash Display title, an
 * optional subtitle, an error/success banner slot, the form body, and a footer
 * (links / step actions). */
export default function MgmtAuthCard({ title, subtitle, error, success, footer, children }) {
  return (
    <MgmtCard className={styles.card}>
      <span className={styles.logo}>
        <img src="/logo-mark.png" alt="" />
        inbox2
      </span>
      <h1 className={styles.title}>{title}</h1>
      {subtitle && <p className={styles.subtitle}>{subtitle}</p>}
      {error && <div className={styles.error} role="alert">{error}</div>}
      {success && <div className={styles.success}>{success}</div>}
      {children}
      {footer && <div className={styles.footer}>{footer}</div>}
    </MgmtCard>
  );
}

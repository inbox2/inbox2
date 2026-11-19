import styles from './MgmtCard.module.css';

/* White rounded management card. `tone="dark"` for a charcoal panel,
 * `tone="glass"` for a frosted panel over a dark surface. */
export default function MgmtCard({ tone = 'light', className, children, ...rest }) {
  const cls = [styles.card, styles[tone] || styles.light, className].filter(Boolean).join(' ');
  return <div className={cls} {...rest}>{children}</div>;
}

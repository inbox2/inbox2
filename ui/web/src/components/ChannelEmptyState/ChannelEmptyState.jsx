import styles from './ChannelEmptyState.module.css';

/* Shared empty-state copy for a single channel / account lane. Shows the
   channel's own identity icon (via accountIconSrc) rather than the generic
   inbox2 cube, so the single-channel inbox and the unified column view read
   the same. Positioning is left to the caller (normal flow or an absolute
   overlay over a ghost-skeleton backdrop). */
export default function ChannelEmptyState({ iconSrc, title, message, children }) {
  return (
    <div className={styles.empty}>
      {iconSrc && <img src={iconSrc} alt="" className={styles.icon} />}
      {title && <div className={styles.title}>{title}</div>}
      {message && <div className={styles.message}>{message}</div>}
      {children}
    </div>
  );
}

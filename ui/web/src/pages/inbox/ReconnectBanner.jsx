import Icon from '../../components/Icon';
import styles from '../../styles/layout.module.css';

// Reconnect banner shown above the list when the open channel's sign-in has
// expired — it can't sync until re-authenticated.
export default function ReconnectBanner({ onReconnect }) {
  return (
    <div className={styles.reauthBanner} role="alert">
      <Icon name="exclamationmark.triangle" size={13} className={styles.reauthBannerIcon} />
      <span className={styles.reauthBannerText}>Sign-in expired</span>
      <button type="button" className={styles.reauthBannerBtn} onClick={onReconnect}>
        Reconnect
      </button>
    </div>
  );
}

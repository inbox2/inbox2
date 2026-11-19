import Icon from '../Icon';
import styles from './RemoteContentBanner.module.css';

/**
 * Graceful degradation for the image privacy proxy: shown when remote images were
 * requested through the proxy but the upstream host refused the server-side fetch
 * (bot-managed CDNs 403 anything that isn't a real browser). The action is an
 * explicit, per-message consent to load just those images directly from this
 * device — the only path that reveals the reader's IP, and only to the hosts that
 * blocked the proxy.
 */
export default function ProxyFailedBanner({ count, onLoadDirect }) {
  return (
    <div className={styles.banner} role="status">
      <Icon name="exclamationmark.triangle" size={14} className={styles.icon} />
      <span className={styles.text}>
        {count === 1 ? 'An image couldn’t load privately.' : `${count} images couldn’t load privately.`}
        {' '}The sender&apos;s image server doesn&apos;t allow it.
      </span>
      <button
        type="button"
        className={styles.solo}
        onClick={onLoadDirect}
        title="Loads from this device. The image server will see your IP address."
      >
        Load directly
      </button>
    </div>
  );
}

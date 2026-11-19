import Icon from '../Icon';
import DropdownMenu from '../DropdownMenu/DropdownMenu';
import styles from './RemoteContentBanner.module.css';

/**
 * Shown above a message body when remote images were blocked and are not being
 * auto-loaded through the privacy proxy. The split button loads them now; the
 * dropdown makes that choice sticky (per sender, or globally).
 */
export default function RemoteContentBanner({ count, onShowOnce, onAlwaysSender, onAlwaysAll }) {
  const items = [
    { label: 'Show images once', onSelect: onShowOnce },
    { label: 'Always show from this sender', onSelect: onAlwaysSender },
    { label: 'Always show images', onSelect: onAlwaysAll },
  ];

  return (
    <div className={styles.banner} role="status">
      <Icon name="photo" size={14} className={styles.icon} />
      <span className={styles.text}>
        {count === 1 ? 'We blocked a remote image' : `We blocked ${count} remote images`} to protect your privacy.
      </span>
      <div className={styles.split}>
        <button type="button" className={styles.action} onClick={onShowOnce}>
          Show images
        </button>
        <DropdownMenu
          align="right"
          trigger={
            <button type="button" className={styles.caret} aria-label="Image options">
              <Icon name="chevron.down" size={9} />
            </button>
          }
          items={items}
        />
      </div>
    </div>
  );
}

import AntennaIcon from '../../components/AnimatedIcons/AntennaIcon';
import styles from '../../styles/layout.module.css';

// Notice on an MX-domain inbox when the domain isn't receiving mail yet — its
// MX/DNS records aren't verified. Owners/admins get the "Set up DNS" action.
export default function MxPendingBanner({ domain, canManageDns, onSetupDns }) {
  return (
    <div className={styles.reauthBanner} role="status">
      <AntennaIcon size={16} color="#3a2c00" className={styles.reauthBannerIcon} />
      <span className={styles.reauthBannerText}>
        {domain
          ? `${domain} isn’t receiving mail yet. Its MX records aren’t verified.`
          : 'This domain isn’t receiving mail yet. Its MX records aren’t verified.'}
      </span>
      {canManageDns && (
        <button type="button" className={styles.reauthBannerBtn} onClick={onSetupDns}>
          Set up DNS
        </button>
      )}
    </div>
  );
}

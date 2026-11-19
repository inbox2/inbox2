import MessageHandlingSettings from './MessageHandlingSettings';
import NotificationSettings from './NotificationSettings';
import SoundSettings from './SoundSettings';
import EmptyStateSettings from './EmptyStateSettings';
import styles from './settings.module.css';

/**
 * The combined Preferences tab: message handling, notifications, sounds, and
 * empty-state, laid out as cards. (Org-level settings are admin-only and live
 * in the admin console.)
 */
export default function PreferencesSettings() {
  return (
    <div className={styles.prefGrid}>
      <section className={styles.settingsPanel}>
        <MessageHandlingSettings />
      </section>
      <section className={styles.settingsPanel}>
        <NotificationSettings />
      </section>
      <section className={styles.settingsPanel}>
        <SoundSettings />
      </section>
      <section className={styles.settingsPanel}>
        <EmptyStateSettings />
      </section>
    </div>
  );
}

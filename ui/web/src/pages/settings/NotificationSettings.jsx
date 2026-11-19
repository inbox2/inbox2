import useNotificationPref, { NOTIFICATION_MODES } from '../../lib/notificationPref';
import useCloudPushPref from '../../lib/cloudPushPref';
import Switch from '../../components/Switch/Switch';
import { MgmtSelect } from '../../components/management';
import styles from './settings.module.css';

const MODE_OPTIONS = [
  { value: NOTIFICATION_MODES.CUSTOM, label: 'inbox2 popup (glass cards)' },
  { value: NOTIFICATION_MODES.SYSTEM, label: 'System notification (macOS / Windows)' },
  { value: NOTIFICATION_MODES.NONE, label: 'Off (activity feed only)' },
];

export default function NotificationSettings() {
  const { mode, setMode } = useNotificationPref();
  const { enabled: cloudPush, setEnabled: setCloudPush } = useCloudPushPref();

  return (
    <>
      <h1 className={styles.settingsTitle}>Notifications</h1>
      <p className={styles.sectionDesc}>
        Choose how you hear about new mail. <strong>Popup</strong> shows glass cards with quick
        actions. <strong>System</strong> uses your computer&rsquo;s notifications. <strong>Off</strong> keeps
        new mail in the activity feed only.
      </p>

      <div className={styles.settingsField}>
        <label htmlFor="notif-mode">New mail alerts</label>
        <MgmtSelect
          bare
          compact
          id="notif-mode"
          value={mode}
          onChange={(e) => setMode(e.target.value)}
          options={MODE_OPTIONS}
        />
      </div>

      <p className={styles.sectionDesc}>
        Set notification sounds in <strong>Settings &rsaquo; Sounds</strong>.
      </p>

      <hr className={styles.settingsGroupDivider} />

      <div className={styles.settingsSectionTitle}>Realtime delivery</div>
      <Switch
        id="cloud-push-enabled"
        label="Cloud push for connected accounts"
        description="Get Gmail and Office 365 mail the moment it arrives. Your sign-in stays on this device. When off, we check every minute."
        checked={cloudPush}
        onChange={setCloudPush}
      />
    </>
  );
}

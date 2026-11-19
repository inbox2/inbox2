import useAuth from '../../hooks/useAuth';
import styles from './settings.module.css';

export default function ProfileSettings() {
  const { user } = useAuth();

  return (
    <>
      <h1 className={styles.settingsTitle}>Your profile</h1>
      <div className={styles.settingsField}>
        <label>Username</label>
        <input value={user?.username || ''} disabled />
      </div>
      <div className={styles.settingsField}>
        <label>Display name</label>
        <input value={user?.display_name || ''} disabled />
      </div>
    </>
  );
}

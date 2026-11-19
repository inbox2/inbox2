import RuleManager from '../../components/CreateRulePopup/RuleManager';
import { isTauri } from '../../lib/tauri';
import styles from './settings.module.css';

/**
 * Settings home for local channel rules (agentic filters) — renders the rule
 * manager inline (list + 3-step editor), no popup. Desktop-only (rules live in
 * local SQLite via Tauri). See docs/Agentic-Filters.md §5.2.
 */
export default function LocalRulesSettings() {
  return (
    <>
      <h1 className={styles.settingsTitle}>Auto rules</h1>

      <p className={styles.sectionDesc}>
        Rules act on mail in your Gmail, Outlook and IMAP accounts. They run on this device.
      </p>

      {isTauri() ? (
        <RuleManager embedded />
      ) : (
        <p className={styles.tableEmpty}>
          Auto rules work in the desktop app.
        </p>
      )}
    </>
  );
}

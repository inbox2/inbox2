import useDropBlockPref from '../../lib/dropBlockPref';
import Switch from '../../components/Switch/Switch';
import styles from './settings.module.css';

/**
 * Reading-pane fun settings — currently just the playable DropBlock game that
 * fills the empty reading pane when no conversation is selected.
 */
export default function EmptyStateSettings() {
  const { enabled, setEnabled } = useDropBlockPref();

  return (
    <>
      <h1 className={styles.settingsTitle}>Reading pane</h1>

      <p className={styles.sectionDesc}>
        With no conversation open, you can play DropBlock in the reading pane. Press <kbd>⏎</kbd> to play.
      </p>

      <Switch
        id="dropblock-enabled"
        label="Play DropBlock in the empty reading pane"
        description="When off, the pane just says “Select a conversation”."
        checked={enabled}
        onChange={setEnabled}
      />
    </>
  );
}

import useMarkReadPref, { MARK_READ_MODES } from '../../lib/markReadPref';
import { MgmtSelect } from '../../components/management';
import styles from './settings.module.css';

const MODE_OPTIONS = [
  { value: MARK_READ_MODES.IMMEDIATE, label: 'As soon as they’re selected' },
  { value: MARK_READ_MODES.DELAY, label: 'After a delay (default)' },
  { value: MARK_READ_MODES.SELECTION_CHANGE, label: 'When the selection changes' },
  { value: MARK_READ_MODES.NEVER, label: 'Don’t automatically mark as read' },
];

export default function MessageHandlingSettings() {
  const { mode, delaySeconds, setMode, setDelaySeconds } = useMarkReadPref();

  return (
    <>
      <h1 className={styles.settingsTitle}>Message handling</h1>

      <p className={styles.sectionDesc}>
        Choose when a conversation you open counts as read.
      </p>

      <div className={styles.settingsField}>
        <label htmlFor="mark-read-mode">Mark as read</label>
        <MgmtSelect
          bare
          compact
          id="mark-read-mode"
          value={mode}
          onChange={(e) => setMode(e.target.value)}
          options={MODE_OPTIONS}
        />
      </div>

      {mode === MARK_READ_MODES.DELAY && (
        <div className={styles.settingsField}>
          <label htmlFor="mark-read-delay">Wait before marking read (seconds)</label>
          <input
            id="mark-read-delay"
            type="number"
            min={0.5}
            max={60}
            step={0.5}
            value={delaySeconds}
            onChange={(e) => setDelaySeconds(e.target.value)}
          />
        </div>
      )}
    </>
  );
}

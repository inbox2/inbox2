import useSoundPref from '../../lib/soundPref';
import {
  RECEIVE_SOUNDS, SEND_SOUNDS, receiveSoundFile, sendSoundFile,
} from '../../lib/soundCatalog';
import { previewSound } from '../../lib/notificationSound';
import Switch from '../../components/Switch/Switch';
import Icon from '../../components/Icon';
import { MgmtSelect } from '../../components/management';
import styles from './settings.module.css';

export default function SoundSettings() {
  const { enabled, receive, send, setEnabled, setReceive, setSend } = useSoundPref();

  return (
    <>
      <h1 className={styles.settingsTitle}>Sounds</h1>
      <p className={styles.sectionDesc}>
        Hear a sound when mail arrives and when you send. Sound effects by{' '}
        <a href="https://mixkit.co" target="_blank" rel="noreferrer noopener">Mixkit</a>.
      </p>

      <Switch
        id="sounds-enabled"
        label="Play sounds"
        description="Turns all mail sounds on or off."
        checked={enabled}
        onChange={setEnabled}
      />

      <hr className={styles.settingsGroupDivider} />

      <div className={styles.settingsField}>
        <label htmlFor="sound-receive">When new mail arrives</label>
        <div className={styles.soundRow}>
          <MgmtSelect
            bare
            compact
            className={styles.soundSelect}
            id="sound-receive"
            value={receive}
            onChange={(e) => setReceive(e.target.value)}
            options={RECEIVE_SOUNDS.map((s) => ({ value: s.id, label: s.label }))}
          />
          <button
            type="button"
            className={styles.soundPreviewBtn}
            onClick={() => previewSound(receiveSoundFile(receive))}
            aria-label="Preview new-mail sound"
          >
            <Icon name="play.fill" size={13} />
          </button>
        </div>
      </div>

      <div className={styles.settingsField}>
        <label htmlFor="sound-send">When you send a message</label>
        <div className={styles.soundRow}>
          <MgmtSelect
            bare
            compact
            className={styles.soundSelect}
            id="sound-send"
            value={send}
            onChange={(e) => setSend(e.target.value)}
            options={SEND_SOUNDS.map((s) => ({ value: s.id, label: s.label }))}
          />
          <button
            type="button"
            className={styles.soundPreviewBtn}
            onClick={() => previewSound(sendSoundFile(send))}
            aria-label="Preview send sound"
          >
            <Icon name="play.fill" size={13} />
          </button>
        </div>
      </div>
    </>
  );
}

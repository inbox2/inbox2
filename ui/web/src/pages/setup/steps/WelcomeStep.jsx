import Button from '../../../components/Button/Button'
import styles from '../setup.module.css'

export default function WelcomeStep({ mode, setMode, onContinue }) {
  return (
    <>
      <h1 className={styles.title}>Welcome to inbox2</h1>
      <p className={styles.subtitle}>How would you like to use the app?</p>

      <div className={styles.modeGrid}>
        <button
          className={`${styles.modeCard} ${mode === 'mx' ? styles.modeCardSelected : ''}`}
          onClick={() => setMode('mx')}
        >
          <div className={styles.radioOuter}>
            {mode === 'mx' && <div className={styles.radioInner} />}
          </div>
          <img src="/logo-mark.png" alt="" className={styles.modeLogoMx} width="48" height="48" />
          <span className={styles.modeLabel}>Connect a domain</span>
          <span className={styles.modeDesc}>
            Run your domain&rsquo;s mail through inbox2.
            Send it to people, AI agents or webhooks.
          </span>
        </button>

        <button
          className={`${styles.modeCard} ${mode === 'standalone' ? styles.modeCardSelected : ''}`}
          onClick={() => setMode('standalone')}
        >
          <div className={styles.radioOuter}>
            {mode === 'standalone' && <div className={styles.radioInner} />}
          </div>
          <div className={styles.modeProviderIcons}>
            <img src="/channels/gmail.svg" alt="" width="28" height="28" />
            <img src="/channels/office365.svg" alt="" width="28" height="28" />
          </div>
          <span className={styles.modeLabel}>Add email accounts</span>
          <span className={styles.modeDesc}>
            Connect your existing Gmail, Office 365, or IMAP accounts.
            Use inbox2 as your desktop mail client.
          </span>
        </button>
      </div>

      <div className={styles.actions}>
        <Button onClick={onContinue} disabled={!mode}>
          Continue
        </Button>
      </div>
    </>
  )
}

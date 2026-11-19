import Button from '../../../components/Button/Button'
import FormField from '../../../components/FormField/FormField'
import { isTauri } from '../../../lib/tauri'
import styles from '../setup.module.css'

function ApolloLogo({ size = 24 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <circle cx="16" cy="16" r="16" fill="#6B4FBB" />
      <path d="M16 6l7.5 18h-3.2l-1.5-3.8h-5.6L11.7 24H8.5L16 6zm0 5.8L13.2 18h5.6L16 11.8z" fill="white" />
    </svg>
  )
}

export default function EnrichmentStep({ apolloKey, setApolloKey, inbox2Key, setInbox2Key, onSave, onSkip, onSignIn }) {
  return (
    <>
      <h1 className={styles.title}>Connect services</h1>
      <p className={styles.subtitle}>
        Optional. Add these now or later in Settings.
      </p>

      <div className={styles.providerCard}>
        <div className={styles.providerCardHeader}>
          <div>
            <h3 className={styles.providerCardName}>Inbox2 Cloud</h3>
            <p className={styles.providerCardDesc}>Private image proxy &amp; push notifications</p>
          </div>
        </div>

        <FormField
          label="API key"
          type="password"
          value={inbox2Key}
          onChange={e => setInbox2Key(e.target.value)}
          placeholder="ink_…"
          autoComplete="off"
          hint={<>Create one in the Inbox2 web app under Settings &rsaquo; API keys</>}
        />

        {isTauri() && onSignIn && (
          <div className={styles.linkRow}>
            <span className={styles.linkOr}>or</span>
            {/* Goes to the app's own /login rather than opening the browser, so
                both halves of onboarding authenticate the same way against the
                same origin. /login still offers the browser device-link, so the
                no-key option isn't lost — it just lives in one place now. */}
            <button type="button" className={styles.linkAction} onClick={onSignIn}>
              Sign in to your inbox2 account
            </button>
            <p className={styles.linkHint}>
              Recommended. Sign in and skip the key.
            </p>
          </div>
        )}
      </div>

      <div className={styles.providerCard}>
        <div className={styles.providerCardHeader}>
          <ApolloLogo size={28} />
          <div>
            <h3 className={styles.providerCardName}>Apollo.io</h3>
            <p className={styles.providerCardDesc}>Contact &amp; company intelligence</p>
          </div>
        </div>

        <FormField
          label="API key"
          type="password"
          value={apolloKey}
          onChange={e => setApolloKey(e.target.value)}
          placeholder="Paste your Apollo API key"
          autoComplete="off"
          hint={<>Find your key at Apollo &rarr; Settings &rarr; Integrations &rarr; API Keys</>}
        />
      </div>

      <div className={styles.actions}>
        <Button onClick={onSave} disabled={!apolloKey.trim() && !inbox2Key.trim()}>
          Save &amp; continue
        </Button>
        <Button variant="ghost" onClick={onSkip}>
          Skip
        </Button>
      </div>
    </>
  )
}

import Button from '../../../components/Button/Button'
import OAuthDevUrl from '../../../components/OAuthDevUrl/OAuthDevUrl'
import styles from '../setup.module.css'

export default function OAuthWaitingStep({ step, provider, onCancel, devMode, authUrl, onOpenUrl }) {
  return (
    <div className={styles.centered}>
      <img src={provider?.icon} alt="" width="64" height="64" />
      <h2 className={styles.title}>
        {step === 'oauth-exchanging' ? 'Connecting…' : 'Sign in with Google'}
      </h2>
      <p className={styles.subtitle}>
        {step === 'oauth-exchanging'
          ? 'Setting up your account…'
          : 'Finish signing in in your browser, then come back here.'}
      </p>
      {step === 'oauth-waiting' && devMode && (
        <OAuthDevUrl url={authUrl} onOpen={onOpenUrl} />
      )}
      {step === 'oauth-waiting' && (
        <Button variant="ghost" onClick={onCancel}>
          Cancel
        </Button>
      )}
    </div>
  )
}

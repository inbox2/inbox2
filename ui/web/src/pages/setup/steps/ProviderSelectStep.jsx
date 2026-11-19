import Button from '../../../components/Button/Button'
import { ErrorMessage } from '../../../components/FormField/FormField'
import { PROVIDER } from '../../../lib/providerTypes'
import styles from '../setup.module.css'

const PROVIDERS = [
  { type: PROVIDER.GMAIL, label: 'Gmail', desc: 'Google Workspace and personal Gmail accounts', icon: '/channels/gmail.svg', available: true },
  { type: PROVIDER.MICROSOFT, label: 'Office 365', desc: 'Microsoft 365 and Outlook accounts', icon: '/channels/office365.svg', available: true },
  { type: PROVIDER.IMAP, label: 'IMAP', desc: 'Any IMAP provider, like Fastmail, Yahoo or your own server', icon: '/channels/imap.svg', available: true },
  // Meta BYOK channels — bring your own Meta app (see docs/Cloud-Push.md Meta).
  { type: PROVIDER.WHATSAPP, label: 'WhatsApp', desc: 'WhatsApp Business via your own Meta app', icon: '/channels/whatsapp.svg', available: true, meta: true },
  { type: PROVIDER.MESSENGER, label: 'Messenger', desc: 'Facebook Messenger + Page comments', icon: '/channels/messenger.svg', available: true, meta: true },
  { type: PROVIDER.INSTAGRAM, label: 'Instagram', desc: 'Instagram DMs, comments & mentions', icon: '/channels/instagram.svg', available: true, meta: true },
]

export default function ProviderSelectStep({ provider, setProvider, error, onContinue, hasExistingAccounts, onSkip }) {
  return (
    <>
      <h1 className={styles.title}>Connect an account</h1>
      <p className={styles.subtitle}>Choose your email provider to get started.</p>

      <ErrorMessage>{error}</ErrorMessage>

      <div className={`${styles.modeGrid} ${styles.modeGrid3}`}>
        {PROVIDERS.map(p => (
          <button
            key={p.type}
            className={`${styles.modeCard} ${provider?.type === p.type ? styles.modeCardSelected : ''} ${!p.available ? styles.modeCardDisabled : ''}`}
            onClick={() => p.available && setProvider(p)}
          >
            <div className={styles.radioOuter}>
              {provider?.type === p.type && <div className={styles.radioInner} />}
            </div>
            <img src={p.icon} alt={p.label} width="48" height="48" />
            <span className={styles.modeLabel}>{p.label}</span>
            <span className={styles.modeDesc}>{!p.available ? 'Coming soon' : p.desc}</span>
          </button>
        ))}
      </div>

      <div className={styles.actions}>
        <Button onClick={onContinue} disabled={!provider}>
          Continue
        </Button>
        {/* Only when the local DB already has channels — otherwise skipping here
            would land the user on an empty inbox with no way back to setup. */}
        {hasExistingAccounts && (
          <Button variant="ghost" onClick={onSkip}>
            I already have accounts
          </Button>
        )}
      </div>
    </>
  )
}

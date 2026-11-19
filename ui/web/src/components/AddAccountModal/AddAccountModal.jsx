import { useState, useEffect, useRef } from 'react'
import Modal from '../Modal/Modal'
import { ErrorMessage } from '../FormField/FormField'
import Button from '../Button/Button'
import useOAuthFlow from '../../hooks/useOAuthFlow'
import useAuth from '../../hooks/useAuth'
import Switch from '../Switch/Switch'
import OAuthDevUrl from '../OAuthDevUrl/OAuthDevUrl'
import DevModeIndicator from '../DevModeIndicator/DevModeIndicator'
import ImapConfigureForm from './ImapConfigureForm'
import MxLoginForm from './MxLoginForm'
import MetaConfigureForm from './MetaConfigureForm'
import InstagramConnectForm from './InstagramConnectForm'
import { PROVIDER, PROVIDER_ICON } from '../../lib/providerTypes'
import { isTauri } from '../../lib/tauri'
import { WA_PATH, setLocalWhatsAppEnabled, useLocalWhatsAppSwitch, waStatus, isNoAccess, waErrorText, waOpenPrivacySettings } from '../../lib/localWhatsApp'
import useNavigationStore from '../../stores/navigationStore'
import styles from './AddAccountModal.module.css'

const PROVIDERS = [
  { type: PROVIDER.GMAIL, label: 'Gmail', icon: '/channels/gmail.svg', available: true },
  { type: PROVIDER.MICROSOFT, label: 'Office 365', icon: '/channels/office365.svg', available: true },
  { type: PROVIDER.IMAP, label: 'IMAP', icon: '/channels/imap.svg', available: true },
  // Meta BYOK channels (see docs/Cloud-Push.md Meta).
  { type: PROVIDER.WHATSAPP, label: 'WhatsApp', icon: '/channels/whatsapp.svg', available: true, meta: true },
  { type: PROVIDER.MESSENGER, label: 'Messenger', icon: '/channels/messenger.svg', available: true, meta: true },
  { type: PROVIDER.INSTAGRAM, label: 'Instagram', icon: '/channels/instagram.svg', available: true, meta: true },
]

export default function AddAccountModal({ open, onClose, onSubmit, onMetaSubmit, onGmailConnected, onMicrosoftConnected, onConnectMx, initialProvider, reconnectEmail }) {
  const [step, setStep] = useState('select')
  const [provider, setProvider] = useState(null)
  const [error, setError] = useState(null)
  const [submitting, setSubmitting] = useState(false)
  const [animating, setAnimating] = useState(false)
  // Cloud credential backup (docs/E2EE.md). On by default, but only effective when
  // signed into an inbox2 (MX) account — the vault is unlocked with that password.
  const [cloudBackup, setCloudBackup] = useState(true)
  const { login, user } = useAuth()
  // Only an MX session (not an API-key-only device) can unlock the vault.
  const canBackup = !!user
  const effectiveBackup = canBackup && cloudBackup

  const handleClose = () => {
    setStep('select')
    setProvider(null)
    setError(null)
    setAnimating(false)
    resetOAuth()
    onClose()
  }

  const { startOAuth, oauthError, resetOAuth, devMode, authUrl, openAuthUrl } = useOAuthFlow({
    step, setStep,
    cloudBackup: effectiveBackup,
    onConnected: (providerType, result, tokens, email) => {
      if (providerType === PROVIDER.GMAIL && onGmailConnected) {
        onGmailConnected(result, tokens.access_token, tokens.refresh_token, email)
      } else if (providerType === PROVIDER.MICROSOFT && onMicrosoftConnected) {
        onMicrosoftConnected(result, tokens.access_token, tokens.refresh_token, email)
      }
      setAnimating(true)
      setTimeout(() => {
        setAnimating(false)
        handleClose()
      }, 700)
    },
    onClose: () => {},
  })

  const displayError = error || oauthError

  // Local WhatsApp: not an account — a read-only window onto WhatsApp Desktop's
  // own database on this Mac (lib/localWhatsApp.js). Turning it on adds a tab.
  // The real switch: demo mode shows the tab regardless, but this control is the setting.
  const localWhatsApp = useLocalWhatsAppSwitch()
  const [waError, setWaError] = useState(null)
  const enableLocalWhatsApp = async () => {
    setWaError(null)
    const status = await waStatus().catch(e => ({ available: false, error: String(e?.message || e) }))
    if (!status.available) { setWaError(status.error || "Can't read WhatsApp on this Mac"); return }
    try {
      await setLocalWhatsAppEnabled(true)
    } catch (e) {
      setWaError(`Couldn't turn on WhatsApp: ${e?.message || e}`)
      return
    }
    handleClose()
    // The app's bound router navigate (this modal also renders outside a router, in Storybook).
    useNavigationStore.getState()._navigate?.(`/${WA_PATH}`)
  }

  // Reconnect mode: opened from a needs_reauth account, scoped to that one
  // provider — and, when known, that one mailbox (sent as login_hint so the
  // provider's consent screen preselects it).
  const reconnecting = !!initialProvider

  const handleSelect = async (p) => {
    if (!p.available) return
    // Local/offline channels only exist in the desktop app; the MX domain
    // sign-in is the only connectable channel on web.
    if (!isTauri()) {
      setError('You need the desktop app for this channel.')
      return
    }

    if (p.type === PROVIDER.GMAIL || p.type === PROVIDER.MICROSOFT) {
      setProvider(p)
      await startOAuth(p.type, { loginHint: reconnecting ? reconnectEmail : undefined })
      return
    }

    if (p.meta) {
      setProvider(p)
      setStep('meta-configure')
      return
    }

    setProvider(p)
    setStep('configure')
  }

  // Animate the genie-out, then close. Shared by the form submit success paths.
  const finishWithAnimation = () => {
    setAnimating(true)
    setTimeout(() => { setAnimating(false); handleClose() }, 700)
  }

  // Meta (WhatsApp/Messenger) submit: build done in the child; here we run the
  // connect (or the self-contained fallback) + animate.
  const handleMetaSubmit = async (request) => {
    setError(null)
    setSubmitting(true)
    try {
      const req = { ...request, cloud_backup: effectiveBackup }
      if (onMetaSubmit) {
        await onMetaSubmit(req)
      } else {
        // Self-contained fallback for render sites that don't pass onMetaSubmit:
        // create + start sync directly (which validates the token, subscribes
        // webhooks, and registers the relay).
        const { invoke } = await import('@tauri-apps/api/core')
        const account = await invoke('add_meta_account', { request: req })
        await invoke('start_sync', { accountKey: account.key }).catch(() => {})
      }
      finishWithAnimation()
    } catch (err) {
      setError(typeof err === 'string' ? err : (err?.message || 'Couldn’t connect. Try again.'))
    } finally {
      setSubmitting(false)
    }
  }

  // Reconnect: when opened with a known provider, jump straight into its flow
  // (OAuth consent for Gmail/Microsoft, the form for IMAP) instead of showing
  // the picker — mirrors the iOS AddAccountView reauth params.
  const autoStarted = useRef(false)
  useEffect(() => {
    if (!open) { autoStarted.current = false; return undefined }
    if (!initialProvider || autoStarted.current) return undefined
    const p = PROVIDERS.find(x => x.type === initialProvider)
    if (!p) return undefined
    autoStarted.current = true
    // Deferred a tick: handleSelect sets state, which must not happen inside
    // the effect body. (IMAP reconnect prefills the expired mailbox's address
    // inside ImapConfigureForm via reconnectEmail.)
    const timer = setTimeout(() => {
      handleSelect(p)
    }, 0)
    return () => clearTimeout(timer)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, initialProvider])

  // IMAP submit: build the request from the child's form, then connect + animate.
  const handleImapSubmit = async (form) => {
    setError(null)
    setSubmitting(true)
    try {
      await onSubmit({
        provider_type: provider.type,
        display_name: form.display_name || form.email_address.split('@')[0],
        email_address: form.email_address,
        host: form.host,
        port: parseInt(form.port, 10),
        use_tls: form.use_tls,
        // SMTP submission (sending). Blank host → derived from the IMAP host
        // server-side (imap.x → smtp.x).
        smtp_host: form.smtp_host || null,
        smtp_port: parseInt(form.smtp_port, 10) || null,
        smtp_use_tls: form.smtp_use_tls,
        username: form.username || form.email_address,
        password: form.password,
        cloud_backup: effectiveBackup,
      })
      finishWithAnimation()
    } catch (err) {
      setError(err.message || 'Couldn’t connect. Try again.')
    } finally {
      setSubmitting(false)
    }
  }

  const handleMxSubmit = async (username, password) => {
    setError(null)
    setSubmitting(true)
    try {
      const result = await login(username, password)
      handleClose()
      onConnectMx?.(result)
    } catch (err) {
      setError(err.message || 'That username and password didn’t work.')
    } finally {
      setSubmitting(false)
    }
  }

  const providerTile = (p) => (
    <button
      key={p.type}
      className={`${styles.tile} ${!p.available ? styles.tileDisabled : ''}`}
      onClick={() => handleSelect(p)}
    >
      <img src={p.icon} alt={p.label} className={styles.tileIcon} width="96" height="96" />
      <span className={styles.tileLabel}>{p.label}</span>
    </button>
  )

  if (!open && !animating) return null

  return (
    <Modal
      open={open}
      onClose={animating ? () => {} : handleClose}
      className={`${styles.modal} ${animating ? styles.modalExit : ''}`}
      overlayClassName={styles.glassOverlay}
    >
        {devMode && <DevModeIndicator className={styles.devIndicator} />}

        {step === 'select' && (
          <div className={styles.selectLayout}>
            <div className={styles.selectLeft}>
              <h1 className={styles.headline}>
                {reconnecting ? `Reconnect ${reconnectEmail || 'your account'}` : 'Connect your accounts'}
              </h1>
              {reconnecting && (
                <p className={styles.reconnectHint}>
                  Your sign-in expired. Sign in again
                  {reconnectEmail ? <> as <strong>{reconnectEmail}</strong></> : null} to keep getting mail.
                </p>
              )}
              <ErrorMessage>{displayError}</ErrorMessage>

              {/* One inbox2 (MX) account per client: hide the MX sign-in once already
                  signed in. Switching accounts requires an explicit Sign out first
                  (which clears the credential-vault session — docs/E2EE.md). */}
              {onConnectMx && !reconnecting && !user && (
                <div className={styles.group}>
                  <span className={styles.groupLabel}>Your domain</span>
                  <div className={styles.grid}>
                    <button className={styles.tile} onClick={() => { setError(null); setStep('mx-login') }}>
                      <img src={PROVIDER_ICON[PROVIDER.INBOX2]} alt="inbox2" className={styles.tileIcon} width="96" height="96" />
                      <span className={styles.tileLabel}>Sign in to your domain</span>
                    </button>
                  </div>
                </div>
              )}

              {/* External mailboxes (Gmail/Office365/IMAP) and social channels
                  are local/offline channels that sync entirely client-side —
                  they only exist in the desktop app. On web, offer the MX
                  domain sign-in above and nothing else. */}
              {!isTauri() ? (
                <p className={styles.reconnectHint}>
                  Gmail, Office 365, IMAP and social channels need the inbox2
                  desktop app.
                </p>
              ) : reconnecting ? (
                <div className={styles.group}>
                  <span className={styles.groupLabel}>Expired channel</span>
                  <div className={styles.grid}>
                    {PROVIDERS.filter(p => p.type === initialProvider).map(providerTile)}
                  </div>
                </div>
              ) : (
                <>
                  {/* Email mailboxes and social channels in separate rows so the
                      wider social set doesn't squish the mailbox tiles. */}
                  <div className={styles.group}>
                    <span className={styles.groupLabel}>External mailboxes</span>
                    <div className={styles.grid}>
                      {PROVIDERS.filter(p => !p.meta).map(providerTile)}
                    </div>
                  </div>
                  <div className={styles.group}>
                    <span className={styles.groupLabel}>Social channels</span>
                    <div className={styles.grid}>
                      {PROVIDERS.filter(p => p.meta).map(providerTile)}
                    </div>
                    {localWhatsApp ? (
                      <p className={styles.localLink}>
                        WhatsApp on this Mac is on.{' '}
                        <button type="button" className={styles.linkButton} onClick={() => { setWaError(null); setLocalWhatsAppEnabled(false).catch(e => setWaError(`Couldn't turn WhatsApp off: ${e?.message || e}`)) }}>Turn off</button>
                      </p>
                    ) : (
                      <p className={styles.localLink}>
                        <button type="button" className={styles.linkButton} onClick={enableLocalWhatsApp}>Use WhatsApp on this Mac</button>
                        {' '}Reads WhatsApp's chats on this Mac. Replies are typed into WhatsApp for you (macOS asks for
                        Accessibility on the first one). For Lore, the messages that ask
                        something of you (and a few before them) go to Jev and your text model, as your local mail
                        does, and Lore keeps its to-do for each chat (title, summary, who asked) in Inbox2 on this Mac.
                      </p>
                    )}
                    {waError && (
                      <ErrorMessage>
                        {waErrorText(waError)}
                        {isNoAccess(waError) && (
                          <>
                            {' '}
                            <button type="button" className={styles.linkButton} onClick={() => waOpenPrivacySettings()}>Open Full Disk Access</button>
                          </>
                        )}
                      </ErrorMessage>
                    )}
                  </div>
                </>
              )}

              {/* Cloud credential backup toggle (docs/E2EE.md). Disabled until the
                  user is signed into their inbox2 account — the vault is unlocked
                  with that password, so an API-key-only device can't use it. */}
              {isTauri() && !reconnecting && (
                <div className={styles.backupToggle}>
                  <Switch
                    id="cloud-backup"
                    checked={effectiveBackup}
                    disabled={!canBackup}
                    onChange={setCloudBackup}
                    label="Save this login to your inbox2 account"
                    description={canBackup
                      ? 'Encrypted so only you can read it. New devices skip this sign-in.'
                      : 'Sign in to your inbox2 account to turn this on.'}
                  />
                </div>
              )}
            </div>
            <div className={styles.selectRight}>
              <img src="/channels/inbox2-box-open.png" alt="" className={styles.heroLogo} />
            </div>
          </div>
        )}

        {step === 'mx-login' && (
          <MxLoginForm
            onBack={() => { setStep('select'); setError(null) }}
            onSubmit={handleMxSubmit}
            submitting={submitting}
            error={displayError}
          />
        )}

        {(step === 'oauth-waiting' || step === 'oauth-exchanging') && (
          <div className={styles.oauthWaiting}>
            <img src={provider?.icon} alt="" width="64" height="64" />
            <h2 className={styles.oauthTitle}>
              {step === 'oauth-exchanging'
                ? (reconnecting ? 'Reconnecting...' : 'Connecting...')
                : reconnecting && reconnectEmail
                  ? `Reconnect ${reconnectEmail}`
                  : `Sign in with ${provider?.label || 'your provider'}`}
            </h2>
            <p className={styles.oauthDesc}>
              {step === 'oauth-exchanging'
                ? 'Setting up your account...'
                : reconnecting && reconnectEmail
                  ? `Finish signing in as ${reconnectEmail} in your browser, then come back.`
                  : 'Finish signing in in your browser, then come back.'}
            </p>
            {step === 'oauth-waiting' && devMode && (
              <OAuthDevUrl url={authUrl} onOpen={openAuthUrl} />
            )}
            {step === 'oauth-waiting' && (
              <Button variant="ghost" className={styles.oauthCancel} onClick={handleClose}>Cancel</Button>
            )}
          </div>
        )}

        {step === 'configure' && (
          <ImapConfigureForm
            provider={provider}
            reconnecting={reconnecting}
            reconnectEmail={reconnectEmail}
            onBack={() => setStep('select')}
            onSubmit={handleImapSubmit}
            submitting={submitting}
            error={displayError}
          />
        )}

        {step === 'meta-configure' && (
          provider?.type === PROVIDER.INSTAGRAM ? (
            <InstagramConnectForm
              provider={provider}
              devMode={devMode}
              onBack={() => setStep('select')}
              onError={setError}
              onSubmitting={setSubmitting}
              onConnected={finishWithAnimation}
              submitting={submitting}
              error={displayError}
            />
          ) : (
            <MetaConfigureForm
              provider={provider}
              onBack={() => setStep('select')}
              onSubmit={handleMetaSubmit}
              submitting={submitting}
              error={displayError}
            />
          )
        )}

        {animating && (
          <div className={styles.genieWrap}>
            <div className={styles.genie}>
              <img src={provider?.icon} alt="" width="64" height="64" />
            </div>
          </div>
        )}
    </Modal>
  )
}

import { useState, useEffect } from 'react'
import FormField, { ErrorMessage } from '../FormField/FormField'
import Button from '../Button/Button'
import Icon from '../Icon'
import useInstagramOAuth from '../../hooks/useInstagramOAuth'
import { isTauri } from '../../lib/tauri'
import styles from './AddAccountModal.module.css'

const META_FORM_INIT = {
  display_name: '', app_id: '', app_secret: '', system_user_token: '',
  facebook_page_id: '', instagram_account_id: '',
  whatsapp_phone_number_id: '', whatsapp_business_account_id: '',
  instagram_app_id: '', instagram_app_secret: '',
}

/**
 * Instagram-Login (OAuth/BYOK) connect step. Owns its own metaForm state and the
 * dev-mode URL preview; drives the OAuth round-trip via useInstagramOAuth.
 *
 * Props:
 *   provider     — { icon, label }
 *   devMode      — show the dev-mode URL preview box
 *   onBack       — return to the provider picker
 *   onError      — (message|null) => void, surfaces an error on the parent
 *   onSubmitting — (bool) => void
 *   onConnected  — () => void, called after the account is created + sync started
 *   submitting   — disables the button + shows the loading label
 *   error        — error message to surface (or null)
 */
export default function InstagramConnectForm({
  provider, devMode, onBack, onError, onSubmitting, onConnected, submitting, error,
}) {
  const [metaForm, setMetaForm] = useState(META_FORM_INIT)
  // Dev-mode preview of the exact Instagram OAuth URLs inbox2 will call/register.
  const [igPreview, setIgPreview] = useState(null)

  const { startInstagramOAuth } = useInstagramOAuth({
    onError, onSubmitting, onConnected,
  })

  const handleMetaChange = (field) => (e) => {
    setMetaForm(prev => ({ ...prev, [field]: e.target.value }))
  }

  // Dev mode: preview the exact Instagram OAuth URLs (authorize + the redirect to
  // register) so mismatches are visible before clicking Connect.
  useEffect(() => {
    if (!devMode || !isTauri()) return undefined
    let cancelled = false
    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        const p = await invoke('instagram_oauth_preview', { appId: metaForm.instagram_app_id || '<app-id>' })
        if (!cancelled) setIgPreview(p)
      } catch { /* preview is best-effort */ }
    })()
    return () => { cancelled = true }
  }, [devMode, metaForm.instagram_app_id])

  return (
    <div className={styles.configureLayout}>
      <div className={styles.configureHeader}>
        <button className={styles.backBtn} onClick={onBack}>
          <Icon name="chevron.left" size={14} /> Back
        </button>
        <img src={provider?.icon} alt="" width="32" height="32" />
        <h2 className={styles.configureName}>Connect {provider?.label}</h2>
      </div>

      <div className={styles.form}>
        <div className={styles.formScroll}>
          <ErrorMessage>{error}</ErrorMessage>
          <p className={styles.reconnectHint}>
            Connect your Instagram <strong>professional</strong> account via Instagram
            Login. In your Instagram app&rsquo;s <em>Valid OAuth Redirect URIs</em>, register{' '}
            <code>https://api.inbox2.com/api/v1/oauth/instagram/callback</code>.
            Credentials stay encrypted on this device.
          </p>
          <FormField label="Instagram app ID" value={metaForm.instagram_app_id} onChange={handleMetaChange('instagram_app_id')} required />
          <FormField label="Instagram app secret" type="password" hint="Encrypted on this device only" value={metaForm.instagram_app_secret} onChange={handleMetaChange('instagram_app_secret')} required />
          {devMode && igPreview && (
            <div className={styles.devUrlBox}>
              <div className={styles.devUrlLabel}>Redirect URI to register (exact)</div>
              <code className={styles.devUrl}>{igPreview.redirect_uri}</code>
              <div className={styles.devUrlLabel}>Authorize URL inbox2 will open</div>
              <code className={styles.devUrl}>{igPreview.authorize_url}</code>
            </div>
          )}
        </div>
        <div className={styles.actions}>
          <Button
            type="button"
            className={styles.btnPrimary}
            disabled={submitting || !metaForm.instagram_app_id || !metaForm.instagram_app_secret}
            onClick={() => startInstagramOAuth(metaForm)}
          >
            {submitting ? 'Waiting for Instagram…' : 'Connect with Instagram'}
          </Button>
        </div>
      </div>
    </div>
  )
}

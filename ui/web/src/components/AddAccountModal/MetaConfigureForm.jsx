import { useState, useEffect, useMemo } from 'react'
import FormField, { ErrorMessage } from '../FormField/FormField'
import Button from '../Button/Button'
import Icon from '../Icon'
import SegmentedControl from '../SegmentedControl/SegmentedControl'
import { MgmtSelect } from '../management'
import { isTauri } from '../../lib/tauri'
import { groupMetaApps, metaAppLabel } from '../../lib/metaApps'
import { PROVIDER } from '../../lib/providerTypes'
import styles from './AddAccountModal.module.css'

const META_FORM_INIT = {
  display_name: '', app_id: '', app_secret: '', system_user_token: '',
  facebook_page_id: '', instagram_account_id: '',
  whatsapp_phone_number_id: '', whatsapp_business_account_id: '',
  instagram_app_id: '', instagram_app_secret: '',
}

/**
 * Meta BYOK configure step for WhatsApp / Messenger. Owns its own form state,
 * the credential-reuse toggle, and the existing-accounts lookup. Builds the
 * connect request and hands it to the parent via `onSubmit(request)`.
 *
 * Props:
 *   provider   — { type, icon, label }
 *   onBack     — return to the provider picker
 *   onSubmit   — async (request) => void
 *   submitting — disables the button + shows the loading label
 *   error      — error message to surface (or null)
 */
export default function MetaConfigureForm({ provider, onBack, onSubmit, submitting, error }) {
  const [metaForm, setMetaForm] = useState(META_FORM_INIT)
  // Existing Meta accounts → credential reuse. `reuseMode` toggles between
  // reusing an existing app's secret/token and entering new ones; `reuseFrom`
  // is the source account key whose on-device credentials get copied.
  const [metaAccounts, setMetaAccounts] = useState([])
  const [reuseMode, setReuseMode] = useState('new')
  const [reuseFrom, setReuseFrom] = useState('')

  const metaApps = useMemo(() => groupMetaApps(metaAccounts), [metaAccounts])

  const handleMetaChange = (field) => (e) => {
    setMetaForm(prev => ({ ...prev, [field]: e.target.value }))
  }

  // Load existing accounts so we can offer reusing another channel's app
  // credentials (desktop-only; Meta is Tauri-gated). When apps exist, default to
  // reuse (the toggle's purpose) and preselect the first.
  useEffect(() => {
    if (!isTauri()) return undefined
    let cancelled = false
    ;(async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core')
        const accts = await invoke('list_external_accounts')
        if (cancelled) return
        setMetaAccounts(accts || [])
        const apps = groupMetaApps(accts || [])
        if (apps.length > 0) {
          setReuseMode('existing')
          setReuseFrom((prev) => prev || apps[0].repKey)
        }
      } catch { /* no existing accounts to reuse */ }
    })()
    return () => { cancelled = true }
  }, [])

  const handleSubmit = (e) => {
    e.preventDefault()
    // Reuse path: copy app secret + System User token from the chosen existing
    // account (core resolves them from its encrypted bundle); only the asset id
    // is supplied here.
    const reusing = reuseMode === 'existing' && !!reuseFrom
    const request = {
      channel: provider.type,
      display_name: metaForm.display_name || null,
      app_id: reusing ? '' : metaForm.app_id,
      app_secret: reusing ? '' : metaForm.app_secret,
      system_user_token: reusing ? '' : metaForm.system_user_token,
      facebook_page_id: metaForm.facebook_page_id || null,
      instagram_account_id: metaForm.instagram_account_id || null,
      whatsapp_phone_number_id: metaForm.whatsapp_phone_number_id || null,
      whatsapp_business_account_id: metaForm.whatsapp_business_account_id || null,
      reuse_credentials_from: reusing ? reuseFrom : null,
    }
    onSubmit(request)
  }

  return (
    <div className={styles.configureLayout}>
      <div className={styles.configureHeader}>
        <button className={styles.backBtn} onClick={onBack}>
          <Icon name="chevron.left" size={14} /> Back
        </button>
        <img src={provider?.icon} alt="" width="32" height="32" />
        <h2 className={styles.configureName}>Connect {provider?.label}</h2>
      </div>

      <form className={styles.form} onSubmit={handleSubmit}>
        <div className={styles.formScroll}>
          <ErrorMessage>{error}</ErrorMessage>

          {/* Connecting auto-subscribes the app's webhook + starts receiving. */}
          <p className={styles.reconnectHint}>
            Bring your own Meta app. Its keys stay encrypted on this device.
            We set up your app&rsquo;s webhook when you connect.
          </p>

          {metaApps.length > 0 && (
            <FormField label="App credentials">
              <SegmentedControl
                aria-label="Meta app credentials source"
                value={reuseMode}
                onChange={setReuseMode}
                options={[
                  { value: 'existing', label: 'Use existing' },
                  { value: 'new', label: 'Add new' },
                ]}
              />
            </FormField>
          )}

          {reuseMode === 'existing' && metaApps.length > 0 ? (
            <FormField label="Meta app" hint="Uses this app's saved secret and System User token">
              <MgmtSelect
                bare
                compact
                value={reuseFrom}
                onChange={(e) => setReuseFrom(e.target.value)}
              >
                {metaApps.map((g) => (
                  <option key={g.key} value={g.repKey}>{metaAppLabel(g)}</option>
                ))}
              </MgmtSelect>
            </FormField>
          ) : (
            <>
              <FormField label="App secret" type="password" hint="Encrypted on this device only" value={metaForm.app_secret} onChange={handleMetaChange('app_secret')} required />
              <FormField label="System User token" type="password" hint="Use a permanent token. It stays encrypted on this device." value={metaForm.system_user_token} onChange={handleMetaChange('system_user_token')} required />
            </>
          )}

          {/* Phone number ID / IG account are auto-detected on connect — no field. */}
          {provider?.type === PROVIDER.WHATSAPP && (
            <FormField label="WhatsApp Business Account ID" value={metaForm.whatsapp_business_account_id} onChange={handleMetaChange('whatsapp_business_account_id')} required />
          )}
          {provider?.type === PROVIDER.MESSENGER && (
            <FormField label="Facebook Page ID" value={metaForm.facebook_page_id} onChange={handleMetaChange('facebook_page_id')} required />
          )}

          {/* App ID + display name are auto-derived from the token — no fields.
              Instagram uses the OAuth form (Instagram-Login path). */}
        </div>

        <div className={styles.actions}>
          <Button type="submit" className={styles.btnPrimary} disabled={submitting}>
            {submitting ? 'Connecting...' : 'Connect'}
          </Button>
        </div>
      </form>
    </div>
  )
}

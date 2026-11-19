import Button from '../../../components/Button/Button'
import FormField, { ErrorMessage } from '../../../components/FormField/FormField'
import SegmentedControl from '../../../components/SegmentedControl/SegmentedControl'
import { MgmtSelect } from '../../../components/management'
import { PROVIDER } from '../../../lib/providerTypes'
import { metaAppLabel } from '../../../lib/metaApps'
import styles from '../setup.module.css'

// Per-channel asset fields. The shared app-secret bundle (app_id, app_secret,
// System User token) is collected for every Meta channel; the asset ids differ.
// Everything is stored encrypted on-device — the secret + token never leave it.
// When other Meta channels are already connected, the app credentials can be
// reused from one of them (`metaApps`) instead of re-entered.
export default function MetaConfigureStep({
  provider, form, onChange, error, loading, onSubmit, onBack,
  metaApps = [], reuseMode = 'new', setReuseMode, reuseFrom = '', setReuseFrom,
}) {
  const type = provider?.type
  const reusing = reuseMode === 'existing' && metaApps.length > 0
  return (
    <>
      <div className={styles.stepHeader}>
        <button className={styles.backBtn} onClick={onBack}>
          &#8592; Back
        </button>
        <img src={provider?.icon} alt="" width="24" height="24" />
        <h2 className={styles.stepTitle}>Connect {provider?.label}</h2>
      </div>

      <form className={styles.form} onSubmit={onSubmit}>
        <ErrorMessage>{error}</ErrorMessage>

        <p className={styles.subtitle}>
          Bring your own Meta app. Your credentials stay encrypted on this device.
          We set up the webhook for you.
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

        {reusing ? (
          <FormField label="Meta app" hint="Reuses this app's secret and System User token, already encrypted here">
            <MgmtSelect bare compact value={reuseFrom} onChange={(e) => setReuseFrom(e.target.value)}>
              {metaApps.map((g) => (
                <option key={g.key} value={g.repKey}>{metaAppLabel(g)}</option>
              ))}
            </MgmtSelect>
          </FormField>
        ) : (
          <>
            <FormField label="App secret" type="password" hint="Encrypted on this device only" value={form.app_secret} onChange={onChange('app_secret')} required />
            <FormField label="System User token" type="password" hint="Permanent token, encrypted on this device only" value={form.system_user_token} onChange={onChange('system_user_token')} required />
          </>
        )}

        {/* WhatsApp phone number ID is auto-detected from the WABA on connect;
            Instagram account from the linked Page — so neither needs a field. */}
        {type === PROVIDER.WHATSAPP && (
          <FormField label="WhatsApp Business Account ID" value={form.whatsapp_business_account_id} onChange={onChange('whatsapp_business_account_id')} required />
        )}

        {type === PROVIDER.MESSENGER && (
          <FormField label="Facebook Page ID" value={form.facebook_page_id} onChange={onChange('facebook_page_id')} required />
        )}

        {type === PROVIDER.INSTAGRAM && (
          <FormField label="Facebook Page ID" hint="Instagram connects via its linked Page" value={form.facebook_page_id} onChange={onChange('facebook_page_id')} required />
        )}

        {/* App ID + display name are auto-derived from the token (debug_token), so
            no fields — leaving just secret + token + one asset id. */}

        <div className={styles.actions}>
          <Button type="submit" disabled={loading}>
            {loading ? 'Connecting...' : 'Connect'}
          </Button>
        </div>
      </form>
    </>
  )
}

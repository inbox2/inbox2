import Button from '../../../components/Button/Button'
import Checkbox from '../../../components/Checkbox/Checkbox'
import FormField, { ErrorMessage } from '../../../components/FormField/FormField'
import styles from '../setup.module.css'

export default function AccountConfigureStep({ provider, form, onChange, error, loading, onSubmit, onBack }) {
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

        <FormField label="Display name" placeholder="Work email" value={form.display_name} onChange={onChange('display_name')} />

        <FormField label="Email address" type="email" placeholder="you@example.com" value={form.email_address} onChange={onChange('email_address')} required />

        <div className={styles.fieldRow}>
          <FormField label="IMAP server" placeholder="imap.example.com" value={form.host} onChange={onChange('host')} required />
          <FormField label="Port" className={styles.fieldGroupSmall} type="number" value={form.port} onChange={onChange('port')} required />
        </div>

        <FormField label="Username" placeholder="Leave blank to use email" value={form.username} onChange={onChange('username')} />

        <FormField label="Password" type="password" placeholder="App password" hint="Encrypted on this device only" value={form.password} onChange={onChange('password')} required />

        <Checkbox checked={form.use_tls} onChange={onChange('use_tls')}>
          Use TLS
        </Checkbox>

        <div className={styles.fieldRow}>
          <FormField label="SMTP server (sending)" placeholder="Leave blank to use the IMAP server" hint="Used for sending mail" value={form.smtp_host} onChange={onChange('smtp_host')} />
          <FormField label="Port" className={styles.fieldGroupSmall} type="number" value={form.smtp_port} onChange={onChange('smtp_port')} />
        </div>

        <Checkbox checked={form.smtp_use_tls} onChange={onChange('smtp_use_tls')}>
          Use TLS for SMTP (port 465). Turn off for STARTTLS on 587.
        </Checkbox>

        <div className={styles.actions}>
          <Button type="submit" disabled={loading}>
            {loading ? 'Connecting…' : 'Connect'}
          </Button>
        </div>
      </form>
    </>
  )
}

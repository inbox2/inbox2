import { useState } from 'react'
import FormField, { ErrorMessage } from '../FormField/FormField'
import Checkbox from '../Checkbox/Checkbox'
import Button from '../Button/Button'
import Icon from '../Icon'
import styles from './AddAccountModal.module.css'

const FORM_INIT = {
  display_name: '', email_address: '', host: '', port: '993',
  use_tls: true, username: '', password: '',
  smtp_host: '', smtp_port: '465', smtp_use_tls: true,
}

/**
 * IMAP configure step. Owns its own form state; the parent performs the actual
 * submit + close via `onSubmit(form)`.
 *
 * Props:
 *   provider     — { icon, label }
 *   reconnecting — reconnect mode (changes the title)
 *   reconnectEmail — known mailbox (reconnect title + email prefill)
 *   onBack       — return to the provider picker
 *   onSubmit     — async (form) => void
 *   submitting   — disables the button + shows the loading label
 *   error        — error message to surface (or null)
 */
export default function ImapConfigureForm({
  provider, reconnecting, reconnectEmail, onBack, onSubmit, submitting, error,
}) {
  // IMAP reconnect prefills the expired mailbox's address (was set on the parent
  // form before handleSelect in the original).
  const [form, setForm] = useState(() => ({
    ...FORM_INIT,
    email_address: reconnecting && reconnectEmail ? reconnectEmail : '',
  }))

  const handleChange = (field) => (e) => {
    const value = e.target.type === 'checkbox' ? e.target.checked : e.target.value
    setForm(prev => ({ ...prev, [field]: value }))
  }

  const handleSubmit = (e) => {
    e.preventDefault()
    onSubmit(form)
  }

  return (
    <div className={styles.configureLayout}>
      <div className={styles.configureHeader}>
        <button className={styles.backBtn} onClick={onBack}>
          <Icon name="chevron.left" size={14} /> Back
        </button>
        <img src={provider?.icon} alt="" width="32" height="32" />
        <h2 className={styles.configureName}>
          {reconnecting && reconnectEmail ? `Reconnect ${reconnectEmail}` : `Connect ${provider?.label}`}
        </h2>
      </div>

      <form className={styles.form} onSubmit={handleSubmit}>
        <div className={styles.formScroll}>
          <ErrorMessage>{error}</ErrorMessage>

          <FormField label="Display name" placeholder="Work email" value={form.display_name} onChange={handleChange('display_name')} />

          <FormField label="Email address" type="email" placeholder="you@example.com" value={form.email_address} onChange={handleChange('email_address')} required />

          <div className={styles.fieldRow}>
            <FormField label="IMAP server" placeholder="imap.example.com" value={form.host} onChange={handleChange('host')} required />
            <FormField label="Port" className={styles.fieldGroupSmall} type="number" value={form.port} onChange={handleChange('port')} required />
          </div>

          <FormField label="Username" placeholder="Leave blank to use email" value={form.username} onChange={handleChange('username')} />

          <FormField label="Password" type="password" placeholder="App password" hint="Encrypted on this device only" value={form.password} onChange={handleChange('password')} required />

          <Checkbox checked={form.use_tls} onChange={handleChange('use_tls')}>
            Use TLS
          </Checkbox>

          <div className={styles.fieldRow}>
            <FormField label="SMTP server (sending)" placeholder="Leave blank to use the IMAP server" hint="Used for sending mail" value={form.smtp_host} onChange={handleChange('smtp_host')} />
            <FormField label="Port" className={styles.fieldGroupSmall} type="number" value={form.smtp_port} onChange={handleChange('smtp_port')} />
          </div>

          <Checkbox checked={form.smtp_use_tls} onChange={handleChange('smtp_use_tls')}>
            Use TLS for SMTP (on 465, or uncheck for STARTTLS on 587)
          </Checkbox>
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

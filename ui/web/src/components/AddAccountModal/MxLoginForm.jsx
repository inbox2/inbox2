import { useState } from 'react'
import Button from '../Button/Button'
import Icon from '../Icon'
import DotMatrix from '../DotMatrix'
import { PROVIDER, PROVIDER_ICON } from '../../lib/providerTypes'
import styles from './AddAccountModal.module.css'
import authStyles from '../../pages/auth/auth.module.css'

/**
 * MX domain sign-in step. Owns its own username/password form state; the parent
 * performs the actual login + close via `onSubmit(username, password)`.
 *
 * Props:
 *   onBack     — return to the provider picker
 *   onSubmit   — async (username, password) => void
 *   submitting — disables the button + shows the loading label
 *   error      — error message to surface (or null)
 */
export default function MxLoginForm({ onBack, onSubmit, submitting, error }) {
  const [mxForm, setMxForm] = useState({ username: '', password: '' })

  const handleMxChange = (field) => (e) => {
    setMxForm(prev => ({ ...prev, [field]: e.target.value }))
  }

  const handleSubmit = (e) => {
    e.preventDefault()
    onSubmit(mxForm.username, mxForm.password)
  }

  return (
    <div className={styles.mxLayout}>
      <DotMatrix pixelGrid />
      <div className={styles.configureHeader}>
        <button className={styles.backBtn} onClick={onBack}>
          <Icon name="chevron.left" size={14} /> Back
        </button>
        <img src={PROVIDER_ICON[PROVIDER.INBOX2]} alt="" width="32" height="32" />
        <h2 className={styles.configureName}>Sign in to your domain</h2>
      </div>

      <div className={styles.mxBody}>
        <form className={`${authStyles.authForm} ${styles.mxForm}`} onSubmit={handleSubmit}>
          {error && <div className={authStyles.authError}>{error}</div>}
          <div className={authStyles.fieldGroup}>
            <label htmlFor="mx-username">Username</label>
            <input
              id="mx-username"
              type="text"
              placeholder="you@yourdomain.com"
              value={mxForm.username}
              onChange={handleMxChange('username')}
              autoComplete="username"
              autoFocus
              required
            />
          </div>
          <div className={authStyles.fieldGroup}>
            <label htmlFor="mx-password">Password</label>
            <input
              id="mx-password"
              type="password"
              placeholder="••••••••"
              value={mxForm.password}
              onChange={handleMxChange('password')}
              autoComplete="current-password"
              required
            />
          </div>
          <Button type="submit" className={authStyles.submitButton} disabled={submitting}>
            <Icon name="arrow.right" size={14} />
            {submitting ? 'Signing in…' : 'Log in'}
          </Button>
        </form>
      </div>
    </div>
  )
}

import { useState } from 'react';
import { Link } from 'react-router';
import api from '../../lib/api';
import { ManagementLayout, MgmtAuthCard, MgmtField, MgmtButton } from '../../components/management';
import styles from './authManagement.module.css';

export default function ForgotPasswordPage() {
  const [email, setEmail] = useState('');
  const [sent, setSent] = useState(false);
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault();
    setLoading(true);
    try {
      await api.resetPasswordRequest(email);
      setSent(true);
    } catch {
      setSent(true); // Always show success to prevent enumeration
    } finally {
      setLoading(false);
    }
  };

  return (
    <ManagementLayout centered brand={false}>
      <MgmtAuthCard
        title="Reset your password"
        subtitle={sent ? null : 'Enter your billing email and we’ll send a reset link.'}
        success={sent ? 'If that email has an account, you’ll get a reset link soon.' : null}
        footer={<Link className={styles.link} to="/login">Back to log in</Link>}
      >
        {!sent && (
          <form className={styles.form} onSubmit={handleSubmit}>
            <MgmtField
              label="Billing email"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="you@external-email.com"
              autoFocus
              required
            />
            <MgmtButton type="submit" variant="primary" block disabled={loading}>
              {loading ? 'Sending…' : 'Send reset link'}
            </MgmtButton>
          </form>
        )}
      </MgmtAuthCard>
    </ManagementLayout>
  );
}

import { useState } from 'react';
import { Link, useSearchParams, useNavigate } from 'react-router';
import api from '../../lib/api';
import { ManagementLayout, MgmtAuthCard, MgmtField, MgmtButton } from '../../components/management';
import styles from './authManagement.module.css';

export default function ResetPasswordPage() {
  const [searchParams] = useSearchParams();
  const token = searchParams.get('token') || '';
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const navigate = useNavigate();

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');
    setLoading(true);
    try {
      await api.resetPassword({ token, password });
      navigate('/login');
    } catch (err) {
      setError(err.message || 'Reset failed');
    } finally {
      setLoading(false);
    }
  };

  return (
    <ManagementLayout centered brand={false}>
      <MgmtAuthCard
        title="Choose a new password"
        error={error || null}
        footer={<Link className={styles.link} to="/login">Back to log in</Link>}
      >
        <form className={styles.form} onSubmit={handleSubmit}>
          <MgmtField
            label="New password"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder="Create a new password"
            autoComplete="new-password"
            autoFocus
            required
          />
          <MgmtButton type="submit" variant="primary" block disabled={loading}>
            {loading ? 'Resetting…' : 'Reset password'}
          </MgmtButton>
        </form>
      </MgmtAuthCard>
    </ManagementLayout>
  );
}

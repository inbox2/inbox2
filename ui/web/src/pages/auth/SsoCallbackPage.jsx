import { useEffect, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import useAuth from '../../hooks/useAuth';
import api from '../../lib/api';
import styles from './auth.module.css';

export default function SsoCallbackPage() {
  const [searchParams] = useSearchParams();
  const provider = searchParams.get('provider');
  const [error, setError] = useState(() => provider ? null : 'Missing provider parameter');
  const [loading, setLoading] = useState(() => !!provider);
  const navigate = useNavigate();
  const { setToken } = useAuth();

  useEffect(() => {
    if (!provider) return;

    api.oauthCallback({
      provider,
      code: searchParams.get('code'),
      uid: searchParams.get('uid'),
      email: searchParams.get('email'),
      name: searchParams.get('name'),
      access_token: searchParams.get('access_token'),
    })
      .then((data) => {
        setToken(data.token);
        navigate(data.new_account ? '/onboarding' : '/');
      })
      .catch((err) => {
        setError(err.message || "Couldn't sign you in");
      })
      .finally(() => setLoading(false));
  }, [provider, searchParams, navigate, setToken]);

  if (loading) {
    return (
      <div className={styles.authPage}>
        <div className={styles.authCard}>
          <h1 className={styles.authTitle}>Signing you in…</h1>
          <p className={styles.authSubtitle}>Finishing single sign-on</p>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className={styles.authPage}>
        <div className={styles.authCard}>
          <h1 className={styles.authTitle}>Sign-in failed</h1>
          <p className={styles.authError}>{error}</p>
          <button className={styles.authButton} onClick={() => navigate('/login')}>
            Back to log in
          </button>
        </div>
      </div>
    );
  }

  return null;
}

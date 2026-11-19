import { useEffect, useRef, useState } from 'react';
import { useSearchParams } from 'react-router';
import api from '../../lib/api';
import AuthLayout from '../../components/AuthLayout/AuthLayout';
import styles from './auth.module.css';

/* The link mailed to a new contact address (docs/TODO.md 48.21). Needs no session:
 * holding the token is the proof. */
export default function ConfirmEmailPage() {
  const [params] = useSearchParams();
  const [state, setState] = useState({ title: 'Confirming', text: 'One moment.' });
  const ran = useRef(false);
  useEffect(() => {
    if (ran.current) return;
    ran.current = true;
    api.confirmContactEmail(params.get('token') || '')
      .then(() => setState({ title: 'Email confirmed', text: 'We now send password resets and account notices to this address.' }))
      .catch((e) => setState({ title: 'Not confirmed', text: e?.data?.errors?.[0]?.message || e?.message || 'Try the link again.' }));
  }, [params]);
  return (
    <AuthLayout title={state.title}>
      <p className={styles.authSubtitle} role="status">{state.text}</p>
    </AuthLayout>
  );
}
